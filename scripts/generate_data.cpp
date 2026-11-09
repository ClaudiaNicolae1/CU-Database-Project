#include<cstdio>
#include<random>
#include<string>
#include<vector>
using namespace std;

mt19937 gen(1);

int rnd(int lo,int hi){
    return lo+gen()%(hi-lo+1);
}

string pick(vector<string>& v){
    return v[rnd(0,v.size()-1)];
}

int main(){
    vector<string> first={"Anna","Ben","Clara","David","Elena","Felix","Greta","Hannah","Ivan","Julia"};
    vector<string> last={"Schmidt","Mueller","Weber","Fischer","Wagner","Becker","Hoffmann","Koch","Richter","Klein"};
    vector<string> street={"Oak Street","Main Street","Mill Road","Church Lane","Station Road"};
    vector<string> city={"Bremen","Hamburg","Berlin","Munich","Vienna","Zurich"};
    vector<string> country={"Germany","Austria","Switzerland","Romania"};
    vector<string> thing={"Lamp","Chair","Notebook","Backpack","Speaker","Kettle"};
    vector<string> category={"books","electronics","home","toys","sports","garden"};
    vector<string> status={"paid","shipped","delivered","returned"};

    FILE* users=fopen("data/users.csv","w");
    FILE* addr=fopen("data/addresses.csv","w");
    FILE* pay=fopen("data/payment_methods.csv","w");
    FILE* prod=fopen("data/products.csv","w");
    FILE* orders=fopen("data/orders.csv","w");
    FILE* items=fopen("data/order_items.csv","w");
    if(!users){
        puts("create the data folder first");
        return 1;
    }

    int a=0;
    for(int u=1;u<=200000;u++){
        // Each random value is drawn in its own statement, in a fixed order. The order in which C++ evaluates
        // function arguments is unspecified, so draws inside one call can differ between compilers.
        // This order is the one GCC used, so the data is the same as in our results.
        string ln=pick(last);
        string fn=pick(first);
        string name=fn+" "+ln;
        int cd=rnd(1,28), cm=rnd(1,12), cy=rnd(2023,2025);
        int nid=rnd(1000000000,2000000000);
        int bd=rnd(1,28), bm=rnd(1,12), by=rnd(1940,2007);
        int phone=rnd(100000000,999999999);
        fprintf(users,"%d,%s,user%d@example.com,+49 %d,%d-%02d-%02d,%d,%d-%02d-%02d\n",u,name.c_str(),u,phone,by,bm,bd,nid,cy,cm,cd);

        int n=1;
        if(rnd(1,10)<=3)n=2;
        for(int k=0;k<n;k++){
            a++;
            string co=pick(country);
            int pc=rnd(10000,99999);
            string ci=pick(city);
            string st=pick(street);
            int no=rnd(1,200);
            fprintf(addr,"%d,%d,%d %s,%s,%d,%s\n",a,u,no,st.c_str(),ci.c_str(),pc,co.c_str());
        }

        int ey=rnd(27,31), em=rnd(1,12);
        int t4=rnd(0,2000000000), t3=rnd(0,2000000000), t2=rnd(0,2000000000), t1=rnd(0,2000000000);
        int last4=rnd(0,9999);
        fprintf(pay,"%d,%d,%s,%04d,%08x%08x%08x%08x,%02d/%d\n",u,u,name.c_str(),last4,t1,t2,t3,t4,em,ey);
    }

    vector<double> price(5001);
    for(int p=1;p<=5000;p++){
        price[p]=rnd(100,50000)/100.0;
        string cat=pick(category);
        int num=rnd(100,999);
        string th=pick(thing);
        fprintf(prod,"%d,%s %d,%s,%.2f\n",p,th.c_str(),num,cat.c_str(),price[p]);
    }

    for(int o=1;o<=1000000;o++){
        double total=0;
        int n=rnd(1,4);
        int p=0;
        for(int i=0;i<n;i++){
            p+=rnd(1,1000);
            int q=rnd(1,5);
            total+=q*price[p];
            fprintf(items,"%d,%d,%d,%.2f\n",o,p,q,price[p]);
        }
        string stt=pick(status);
        int od=rnd(1,28), om=rnd(1,12), oy=rnd(2024,2025);
        int uid=rnd(1,200000);
        fprintf(orders,"%d,%d,%d-%02d-%02d,%s,%.2f\n",o,uid,oy,om,od,stt.c_str(),total);
    }

    fclose(users);
    fclose(addr);
    fclose(pay);
    fclose(prod);
    fclose(orders);
    fclose(items);
    puts("done");
    return 0;
}
