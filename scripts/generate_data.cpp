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
        string name=pick(first)+" "+pick(last);
        fprintf(users,"%d,%s,user%d@example.com,+49 %d,%d-%02d-%02d,%d,%d-%02d-%02d\n",u,name.c_str(),u,rnd(100000000,999999999),rnd(1940,2007),rnd(1,12),rnd(1,28),rnd(1000000000,2000000000),rnd(2023,2025),rnd(1,12),rnd(1,28));

        int n=1;
        if(rnd(1,10)<=3)n=2;
        for(int k=0;k<n;k++){
            a++;
            fprintf(addr,"%d,%d,%d %s,%s,%d,%s\n",a,u,rnd(1,200),pick(street).c_str(),
                pick(city).c_str(),rnd(10000,99999),pick(country).c_str());
        }

        fprintf(pay,"%d,%d,%s,%04d,%08x%08x%08x%08x,%02d/%d\n",u,u,name.c_str(),rnd(0,9999),
            rnd(0,2000000000),rnd(0,2000000000),rnd(0,2000000000),rnd(0,2000000000),rnd(1,12),rnd(27,31));
    }

    vector<double> price(5001);
    for(int p=1;p<=5000;p++){
        price[p]=rnd(100,50000)/100.0;
        fprintf(prod,"%d,%s %d,%s,%.2f\n",p,pick(thing).c_str(),rnd(100,999),pick(category).c_str(),price[p]);
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
        fprintf(orders,"%d,%d,%d-%02d-%02d,%s,%.2f\n",o,rnd(1,200000),rnd(2024,2025),
            rnd(1,12),rnd(1,28),pick(status).c_str(),total);
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
